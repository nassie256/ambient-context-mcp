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
using AmbientContextMcp.Resources;

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
        LoadUiSettings();
        _initialLanguage = GetSelectedLanguage();
        RefreshSelectAllTransmissionCheckBox();
        McpAutoStartCheckBox.IsChecked = _autostart.IsEnabled();
        McpPortBox.Text = _mcpHost.Settings.Port.ToString(CultureInfo.InvariantCulture);
        RefreshMcpStatus();

        SourceInitialized += (_, _) => RestoreWindowStatus();
    }

    private string _initialLanguage = "";

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
        SaveUiSettings();
        ApplyAutostart();

        _collector.ReloadTransmissionPolicy();
        _hub.ReloadSettings();
        _mcpHost.ReloadSettings();

        var languageChanged = !string.Equals(GetSelectedLanguage(), _initialLanguage, StringComparison.OrdinalIgnoreCase);
        SettingsStatusText.Text = languageChanged ? Strings.StatusSavedNeedsRestart : Strings.StatusSaved;
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
        SafeCopy(McpClientSnippets.BuildClaudeCodeSnippet(_mcpHost.McpUrl, _mcpHost.Token));
        SettingsStatusText.Text = Strings.StatusClaudeCodeCopied;
    }

    private void RefreshMcpStatus()
    {
        McpStatusText.Text = string.Format(
            CultureInfo.InvariantCulture,
            Strings.StatusMcpRunningFormat,
            _mcpHost.Settings.Port);
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
        PersistEventLogCheckBox.IsChecked = settings.PersistEventLog;
    }

    private void SaveLocalContextSettings()
    {
        _settingsStore.SaveLocalContextSettings(new LocalContextSettings
        {
            SchemaVersion = 1,
            MaxEventAgeHours = GetComboBoxIntValue(EventRetentionHoursBox, 24),
            MaxEventCount = GetComboBoxIntValue(EventRetentionCountBox, 500),
            PersistEventLog = PersistEventLogCheckBox.IsChecked == true
        });
    }

    private void LoadUiSettings()
    {
        var settings = _settingsStore.LoadUiSettings();
        var target = settings.Language ?? "";
        foreach (var item in UiLanguageBox.Items.OfType<ComboBoxItem>())
        {
            if (string.Equals(item.Tag?.ToString() ?? "", target, StringComparison.OrdinalIgnoreCase))
            {
                UiLanguageBox.SelectedItem = item;
                return;
            }
        }

        UiLanguageBox.SelectedIndex = 0;
    }

    private void SaveUiSettings()
    {
        _settingsStore.SaveUiSettings(new UiSettings
        {
            SchemaVersion = 1,
            Language = GetSelectedLanguage()
        });
    }

    private string GetSelectedLanguage()
    {
        return UiLanguageBox.SelectedValue?.ToString() ?? "";
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
            Option("foregroundApp.category", Strings.TxOptForegroundCategory, "medium"),
            Option("foregroundApp.appName", Strings.TxOptForegroundAppName, "medium"),
            Option("foregroundApp.processName", Strings.TxOptForegroundProcessName, "medium"),
            Option("foregroundApp.titleSummary", Strings.TxOptForegroundTitleSummary, "medium"),
            Option("foregroundApp.rawWindowTitle", Strings.TxOptForegroundRawWindowTitle, "high"),
            // events.foreground_app_category_changed は廃止済み (foreground_changed の category_changed フラグに統合)。
            // UI から外し、ユーザーが新規に opt-in できないようにする。既存 override は classification 経由で残り、
            // 発火しなくなった event に対しても無害。
            Option("events.foreground_changed", Strings.TxOptEventForegroundChanged, "medium"),
            Option("activity.contextSwitchesPerMin", Strings.TxOptActivityContextSwitches, "medium"),
            Option("events.context_switch_burst", Strings.TxOptEventContextSwitchBurst, "medium"),
            Option("media.isAvailable", Strings.TxOptMediaIsAvailable, "medium"),
            Option("media.playbackStatus", Strings.TxOptMediaPlaybackStatus, "medium"),
            Option("media.sourceAppUserModelId", Strings.TxOptMediaSourceApp, "medium"),
            Option("media.title", Strings.TxOptMediaTitle, "high"),
            Option("media.artist", Strings.TxOptMediaArtist, "high"),
            Option("media.albumTitle", Strings.TxOptMediaAlbumTitle, "high"),
            Option("events.media_playback_started", Strings.TxOptEventMediaPlaybackStarted, "medium"),
            Option("events.media_playback_paused", Strings.TxOptEventMediaPlaybackPaused, "medium"),
            Option("events.media_session_changed", Strings.TxOptEventMediaSessionChanged, "medium"),
            Option("events.media_session_changed.title", Strings.TxOptEventMediaSessionChangedTitle, "high"),
            Option("events.media_session_changed.artist", Strings.TxOptEventMediaSessionChangedArtist, "high"),
            Option("system.timeZoneId", Strings.TxOptSystemTimeZone, "medium"),
            Option("display.count", Strings.TxOptDisplayCount, "medium"),
            Option("displays", Strings.TxOptDisplays, "medium")
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
