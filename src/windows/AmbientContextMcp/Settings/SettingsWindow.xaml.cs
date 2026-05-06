using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using AmbientContextMcp.AmbientContext;
using ComboBox = System.Windows.Controls.ComboBox;
using ComboBoxItem = System.Windows.Controls.ComboBoxItem;
using Clipboard = System.Windows.Clipboard;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Policy;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;

namespace AmbientContextMcp.Settings;

public partial class SettingsWindow : Window
{
    private const double MinVisibleDip = 32.0;

    private readonly ISettingsStore _settingsStore;
    private readonly McpServerHost _mcpHost;
    private readonly LocalContextHub _hub;
    private readonly WindowsAmbientContextService _collector;
    private readonly AutostartManager _autostart;
    private readonly List<TransmissionOptionViewModel> _transmissionOptions;

    public SettingsWindow(
        ISettingsStore settingsStore,
        McpServerHost mcpHost,
        LocalContextHub hub,
        WindowsAmbientContextService collector,
        AutostartManager autostart)
    {
        InitializeComponent();
        _settingsStore = settingsStore;
        _mcpHost = mcpHost;
        _hub = hub;
        _collector = collector;
        _autostart = autostart;
        _transmissionOptions = CreateTransmissionOptions();
        TransmissionOptionsList.ItemsSource = _transmissionOptions;

        LoadTransmissionSettings();
        LoadLocalContextSettings();
        RefreshSelectAllTransmissionCheckBox();
        McpAutoStartCheckBox.IsChecked = _autostart.IsEnabled();
        McpPortBox.Text = _mcpHost.Settings.Port.ToString(CultureInfo.InvariantCulture);
        RefreshMcpStatus();

        SourceInitialized += (_, _) => RestoreWindowStatus();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        SaveWindowStatus();
        base.OnClosing(e);
    }

    private void OnToggleAllTransmissionClick(object sender, RoutedEventArgs e)
    {
        var allowAll = SelectAllTransmissionCheckBox.IsChecked == true;
        foreach (var option in _transmissionOptions)
        {
            option.IsAllowed = allowAll;
        }

        RefreshSelectAllTransmissionCheckBox();
    }

    private void OnTransmissionOptionClick(object sender, RoutedEventArgs e)
    {
        RefreshSelectAllTransmissionCheckBox();
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        SaveMcpSettings();
        SaveTransmissionSettings();
        SaveLocalContextSettings();
        ApplyAutostart();

        _collector.ReloadTransmissionPolicy();
        _hub.ReloadSettings();
        _mcpHost.ReloadSettings();

        SettingsStatusText.Text = "保存しました。送信設定は次回の文脈更新から反映されます。ポート変更はアプリ再起動後に有効になります。";
        RefreshMcpStatus();
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private void OnCopyEndpointClick(object sender, RoutedEventArgs e)
    {
        SafeCopy(McpEndpointBox.Text);
    }

    private void OnCopyTokenClick(object sender, RoutedEventArgs e)
    {
        SafeCopy(McpTokenBox.Text);
    }

    private void OnCopyClaudeCodeSnippetClick(object sender, RoutedEventArgs e)
    {
        var snippet =
            $"claude mcp add ambient-context " +
            $"--transport http {_mcpHost.McpUrl} " +
            $"--header \"Authorization: Bearer {_mcpHost.Token}\"";
        SafeCopy(snippet);
        SettingsStatusText.Text = "Claude Code 用のコマンドをクリップボードにコピーしました。";
    }

    private void RefreshMcpStatus()
    {
        McpStatusText.Text = $"起動中 :{_mcpHost.Settings.Port}";
        McpEndpointBox.Text = _mcpHost.McpUrl;
        McpTokenBox.Text = _mcpHost.Token;
    }

    private void SaveMcpSettings()
    {
        var current = _mcpHost.Settings;
        var port = ParsePort(McpPortBox.Text, current.Port);
        _settingsStore.SaveMcpServerSettings(new McpServerSettings
        {
            SchemaVersion = 1,
            AutoStart = McpAutoStartCheckBox.IsChecked == true,
            Port = port,
            Token = current.Token
        });
    }

    private void ApplyAutostart()
    {
        var enabled = McpAutoStartCheckBox.IsChecked == true;
        if (enabled)
        {
            _autostart.Enable(AutostartManager.GetExecutablePath());
        }
        else
        {
            _autostart.Disable();
        }
    }

    private void LoadTransmissionSettings()
    {
        var settings = _settingsStore.LoadAmbientTransmissionSettings();
        foreach (var option in _transmissionOptions)
        {
            option.IsAllowed = settings.PathTransmitOverrides.TryGetValue(option.Path, out var allowed) && allowed;
        }
    }

    private void RefreshSelectAllTransmissionCheckBox()
    {
        SelectAllTransmissionCheckBox.IsChecked =
            _transmissionOptions.Count > 0 && _transmissionOptions.All(option => option.IsAllowed);
    }

    private void SaveTransmissionSettings()
    {
        var settings = _settingsStore.LoadAmbientTransmissionSettings();
        var overrides = new Dictionary<string, bool>(
            settings.PathTransmitOverrides,
            StringComparer.OrdinalIgnoreCase);

        foreach (var option in _transmissionOptions)
        {
            if (option.IsAllowed)
            {
                overrides[option.Path] = true;
            }
            else
            {
                overrides.Remove(option.Path);
            }
        }

        AmbientTransmissionPolicy.Save(
            _settingsStore,
            new AmbientTransmissionSettings
            {
                SchemaVersion = 1,
                PathTransmitOverrides = overrides
            },
            WindowsAmbientContextService.GetPrivacyClassificationsForUi());
    }

    private void LoadLocalContextSettings()
    {
        var settings = _settingsStore.LoadLocalContextSettings();
        SelectComboBoxValue(EventRetentionHoursBox, settings.MaxEventAgeHours);
        SelectComboBoxValue(EventRetentionCountBox, settings.MaxEventCount);
    }

    private void SaveLocalContextSettings()
    {
        _settingsStore.SaveLocalContextSettings(new LocalContextSettings
        {
            SchemaVersion = 1,
            MaxEventAgeHours = GetComboBoxIntValue(EventRetentionHoursBox, 24),
            MaxEventCount = GetComboBoxIntValue(EventRetentionCountBox, 500)
        });
    }

    private static int ParsePort(string text, int fallback)
    {
        return int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var port) &&
               port is > 0 and < 65536
            ? port
            : fallback;
    }

    private static void SelectComboBoxValue(ComboBox comboBox, int value)
    {
        foreach (var item in comboBox.Items.OfType<ComboBoxItem>())
        {
            if (int.TryParse(item.Tag?.ToString(), out var tagValue) && tagValue == value)
            {
                comboBox.SelectedItem = item;
                return;
            }
        }

        comboBox.SelectedIndex = 0;
    }

    private static int GetComboBoxIntValue(ComboBox comboBox, int fallback)
    {
        if (comboBox.SelectedValue is not null &&
            int.TryParse(comboBox.SelectedValue.ToString(), out var selectedValue))
        {
            return selectedValue;
        }

        return fallback;
    }

    private static List<TransmissionOptionViewModel> CreateTransmissionOptions()
    {
        return
        [
            Option("foregroundApp.category", "作業カテゴリ", "medium"),
            Option("foregroundApp.appName", "アプリ名", "medium"),
            Option("foregroundApp.processName", "プロセス名", "medium"),
            Option("foregroundApp.titleSummary", "ウィンドウタイトル要約", "medium"),
            Option("foregroundApp.rawWindowTitle", "ウィンドウタイトル原文", "high"),
            Option("events.foreground_app_category_changed", "作業カテゴリの遷移イベント", "medium"),
            Option("activity.contextSwitchesPerMin", "アプリ切替頻度", "medium"),
            Option("events.context_switch_burst", "アプリ切替増加イベント", "medium"),
            Option("media.isAvailable", "メディアセッション有無", "medium"),
            Option("media.playbackStatus", "メディア再生状態", "medium"),
            Option("media.sourceAppUserModelId", "メディア再生元アプリ", "medium"),
            Option("media.title", "メディアタイトル", "high"),
            Option("media.artist", "メディアアーティスト", "high"),
            Option("media.albumTitle", "メディアアルバム", "high"),
            Option("events.media_playback_started", "メディア再生開始イベント", "medium"),
            Option("events.media_playback_paused", "メディア一時停止イベント", "medium"),
            Option("events.media_session_changed", "メディアセッション変更イベント", "medium"),
            Option("events.media_session_changed.title", "メディアセッション変更イベント: タイトル", "high"),
            Option("events.media_session_changed.artist", "メディアセッション変更イベント: アーティスト", "high"),
            Option("system.timeZoneId", "タイムゾーン", "medium"),
            Option("display.count", "ディスプレイ数", "medium"),
            Option("displays", "ディスプレイ構成", "medium")
        ];
    }

    private static TransmissionOptionViewModel Option(string path, string label, string sensitivity)
    {
        return new TransmissionOptionViewModel
        {
            Path = path,
            Label = label,
            Sensitivity = sensitivity
        };
    }

    private void RestoreWindowStatus()
    {
        try
        {
            var status = _settingsStore.LoadSettingsWindowStatus();
            if (status is null)
            {
                return;
            }

            Width = Math.Max(MinWidth, status.Width);
            Height = Math.Max(MinHeight, status.Height);

            if (IsFinite(status.Left) && IsFinite(status.Top))
            {
                WindowStartupLocation = WindowStartupLocation.Manual;
                Left = status.Left;
                Top = status.Top;
                KeepWindowOnScreen();
            }
        }
        catch
        {
            // Ignore invalid placement files.
        }
    }

    private void SaveWindowStatus()
    {
        if (WindowState == WindowState.Minimized)
        {
            return;
        }

        try
        {
            _settingsStore.SaveSettingsWindowStatus(new SettingsWindowStatus
            {
                SchemaVersion = 1,
                Left = RestoreBounds.Left,
                Top = RestoreBounds.Top,
                Width = RestoreBounds.Width,
                Height = RestoreBounds.Height
            });
        }
        catch
        {
            // Window placement persistence is best effort.
        }
    }

    private void KeepWindowOnScreen()
    {
        var virtualLeft = SystemParameters.VirtualScreenLeft;
        var virtualTop = SystemParameters.VirtualScreenTop;
        var virtualRight = virtualLeft + SystemParameters.VirtualScreenWidth;
        var virtualBottom = virtualTop + SystemParameters.VirtualScreenHeight;

        if (Left + Width < virtualLeft)
        {
            Left = virtualLeft;
        }
        else if (Left > virtualRight - MinVisibleDip)
        {
            Left = virtualRight - Math.Min(Width, SystemParameters.VirtualScreenWidth);
        }

        if (Top + Height < virtualTop)
        {
            Top = virtualTop;
        }
        else if (Top > virtualBottom - MinVisibleDip)
        {
            Top = virtualBottom - Math.Min(Height, SystemParameters.VirtualScreenHeight);
        }
    }

    private static bool IsFinite(double value)
    {
        return !double.IsNaN(value) && !double.IsInfinity(value);
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
            // Best effort.
        }
    }

    private sealed class TransmissionOptionViewModel : INotifyPropertyChanged
    {
        private bool _isAllowed;

        public string Path { get; init; } = "";

        public string Label { get; init; } = "";

        public string Sensitivity { get; init; } = "medium";

        public bool IsAllowed
        {
            get => _isAllowed;
            set
            {
                if (_isAllowed == value)
                {
                    return;
                }

                _isAllowed = value;
                OnPropertyChanged();
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;

        private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
