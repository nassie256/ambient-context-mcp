using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using AmbientContextMcp.AmbientContext;
using ComboBox = System.Windows.Controls.ComboBox;
using ComboBoxItem = System.Windows.Controls.ComboBoxItem;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Policy;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Resources;

namespace AmbientContextMcp.Settings;

public partial class SettingsWindow : Window
{
    private readonly ISettingsStore _settingsStore;
    private readonly McpServerHost _mcpHost;
    private readonly LocalContextHub _hub;
    private readonly WindowsAmbientContextService _collector;
    private readonly AutostartManager _autostart;
    private readonly List<TransmissionGroupViewModel> _transmissionGroups;
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
        _transmissionGroups = TransmissionGroupViewModel.CreateAll();
        _transmissionOptions = _transmissionGroups.SelectMany(group => group.Options).ToList();
        TransmissionGroupsList.ItemsSource = _transmissionGroups;

        LoadTransmissionSettings();
        LoadLocalContextSettings();
        LoadUiSettings();
        _initialLanguage = GetSelectedLanguage();
        RefreshSelectAllTransmissionCheckBox();
        McpAutoStartCheckBox.IsChecked = _autostart.IsEnabled();
        McpPortBox.Text = _mcpHost.Settings.Port.ToString(CultureInfo.InvariantCulture);
        RefreshMcpStatus();

        SourceInitialized += (_, _) => SettingsWindowPlacement.Restore(this, _settingsStore);
        AppDiagnosticLog.Log("settings", "window_created");
    }

    private string _initialLanguage = "";

    protected override void OnClosing(CancelEventArgs e)
    {
        AppDiagnosticLog.Log("settings", "window_closing");
        SettingsWindowPlacement.Save(this, _settingsStore);
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
        AppDiagnosticLog.Log("settings", "save_begin");
        var saveStartedAt = Environment.TickCount64;

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

        AppDiagnosticLog.Log("settings", "save_end", new Dictionary<string, object?>
        {
            ["durationMs"] = Environment.TickCount64 - saveStartedAt,
            ["languageChanged"] = languageChanged
        });
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private void OnCopyEndpointClick(object sender, RoutedEventArgs e)
    {
        ClipboardHelper.SafeCopy(McpEndpointBox.Text);
    }

    private void OnCopyTokenClick(object sender, RoutedEventArgs e)
    {
        ClipboardHelper.SafeCopy(McpTokenBox.Text);
    }

    private void OnCopyClaudeCodeSnippetClick(object sender, RoutedEventArgs e)
    {
        ClipboardHelper.SafeCopy(McpClientSnippets.BuildClaudeCodeSnippet(_mcpHost.McpUrl, _mcpHost.Token));
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
            option.IsAllowed = TransmissionUiSettingsMerge.IsOptionEnabled(
                option.PrimaryPath,
                settings.PathTransmitOverrides);
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
        var enabledOptionIds = _transmissionOptions
            .Where(option => option.IsAllowed)
            .Select(option => option.Id)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var catalogOptions = AmbientContextCatalog.GetTransmissionUiGroups()
            .SelectMany(group => group.Options)
            .ToList();
        var overrides = TransmissionUiSettingsMerge.MergeOverrides(
            settings.PathTransmitOverrides,
            catalogOptions,
            enabledOptionIds);

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

}
