using System.ComponentModel;
using System.Globalization;
using AmbientContextMcp.AmbientContext;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Policy;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Resources;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace AmbientContextMcp.Settings;

public sealed partial class SettingsWindow : Window
{
    private readonly ISettingsStore _settingsStore;
    private readonly McpServerHost _mcpHost;
    private readonly LocalContextHub _hub;
    private readonly WindowsAmbientContextService _collector;
    private readonly AutostartManager _autostart;
    private readonly List<TransmissionGroupViewModel> _transmissionGroups;
    private readonly List<TransmissionOptionViewModel> _transmissionOptions;
    private string _initialLanguage = "";

    public SettingsWindow(
        ISettingsStore settingsStore,
        McpServerHost mcpHost,
        LocalContextHub hub,
        WindowsAmbientContextService collector,
        AutostartManager autostart)
    {
        _settingsStore = settingsStore;
        _mcpHost = mcpHost;
        _hub = hub;
        _collector = collector;
        _autostart = autostart;
        _transmissionGroups = TransmissionGroupViewModel.CreateAll();
        _transmissionOptions = _transmissionGroups.SelectMany(g => g.Options).ToList();

        InitializeComponent();
        Title = Strings.WindowTitle;
        SystemBackdrop = new MicaBackdrop();
        SettingsWindowPlacement.Apply(this, _settingsStore);

        ApplyLabels();
        WireTransmissionItems();

        TransmissionGroupsList.ItemsSource = _transmissionGroups;
        LoadTransmissionSettings();
        LoadLocalContextSettings();
        LoadUiSettings();
        _initialLanguage = GetSelectedLanguage();
        RefreshSelectAllTransmissionCheckBox();
        McpAutoStartCheckBox.IsChecked = _autostart.IsEnabled();
        McpPortBox.Text = _mcpHost.Settings.Port.ToString(CultureInfo.InvariantCulture);
        RefreshMcpStatus();

        AppDiagnosticLog.Log("settings", "window_created");
        Closed += OnWindowClosed;
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        AppDiagnosticLog.Log("settings", "window_closing");
    }

    private void ApplyLabels()
    {
        // Pivot タブヘッダー
        McpServerTab.Header = Strings.TabMcpServer;
        TransmissionTab.Header = Strings.TabTransmission;

        // MCP Server タブ
        McpServerGroupText.Text = Strings.McpServerGroup;
        LabelStatusText.Text = Strings.LabelStatus;
        LabelEndpointText.Text = Strings.LabelEndpoint;
        CopyEndpointButton.Content = Strings.ButtonCopy;
        LabelTokenText.Text = Strings.LabelToken;
        CopyTokenButton.Content = Strings.ButtonCopy;
        LabelPortText.Text = Strings.LabelPort;
        PortChangeNoteText.Text = Strings.PortChangeNote;
        McpAutoStartCheckBox.Content = Strings.AutoStartCheckbox;
        PersistEventLogCheckBox.Content = Strings.PersistEventLogCheckbox;
        PersistEventLogNoteText.Text = Strings.PersistEventLogNote;
        CopySnippetButton.Content = Strings.CopyClaudeCodeSnippet;

        // 言語
        LabelLanguageText.Text = Strings.LabelLanguage;
        LanguageSystemDefaultItem.Content = Strings.LanguageSystemDefault;
        LanguageJapaneseItem.Content = Strings.LanguageJapanese;
        LanguageEnglishItem.Content = Strings.LanguageEnglish;

        // Transmission タブ
        TransmissionExplanationText.Text = Strings.TransmissionExplanation;
        SelectAllTransmissionCheckBox.Content = Strings.AllowAllCheckbox;
        EventHistoryGroupText.Text = Strings.EventHistoryGroup;
        SensitivityLegendText.Text = Strings.SensitivityLegend;
        LabelRetentionText.Text = Strings.LabelRetention;
        LabelMaxCountText.Text = Strings.LabelMaxCount;
        Retention1HourItem.Content = Strings.Retention1Hour;
        Retention6HoursItem.Content = Strings.Retention6Hours;
        Retention24HoursItem.Content = Strings.Retention24Hours;
        Retention7DaysItem.Content = Strings.Retention7Days;
        Count100Item.Content = Strings.Count100;
        Count500Item.Content = Strings.Count500;
        Count1000Item.Content = Strings.Count1000;
        Count5000Item.Content = Strings.Count5000;

        // ボタン
        SaveButton.Content = Strings.ButtonSave;
        CloseButton.Content = Strings.ButtonClose;
    }

    private void WireTransmissionItems()
    {
        foreach (var option in _transmissionOptions)
        {
            option.PropertyChanged += OnTransmissionOptionPropertyChanged;
        }
    }

    private void OnTransmissionOptionPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TransmissionOptionViewModel.IsAllowed))
        {
            RefreshSelectAllTransmissionCheckBox();
        }
    }

    private void OnToggleAllTransmissionClick(object sender, RoutedEventArgs e)
    {
        var allow = SelectAllTransmissionCheckBox.IsChecked == true;
        foreach (var option in _transmissionOptions) option.IsAllowed = allow;
    }

    private void RefreshSelectAllTransmissionCheckBox()
    {
        SelectAllTransmissionCheckBox.IsChecked =
            _transmissionOptions.Count > 0 && _transmissionOptions.All(o => o.IsAllowed);
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        AppDiagnosticLog.Log("settings", "save_begin");
        var startedAt = Environment.TickCount64;

        try
        {
            SaveStep("save_mcp", SaveMcpSettings);
            SaveStep("save_transmission", SaveTransmissionSettings);
            SaveStep("save_local_context", SaveLocalContextSettings);
            SaveStep("save_ui", SaveUiSettings);
            SaveStep("apply_autostart", ApplyAutostart);
            SaveStep("reload_collector", () => _collector.ReloadTransmissionPolicy());
            SaveStep("reload_hub", () => _hub.ReloadSettings());
            SaveStep("reload_mcp", () => _mcpHost.ReloadSettings());

            var langChanged = !string.Equals(GetSelectedLanguage(), _initialLanguage, StringComparison.OrdinalIgnoreCase);
            SettingsStatusText.Text = langChanged ? Strings.StatusSavedNeedsRestart : Strings.StatusSaved;
            RefreshMcpStatus();

            AppDiagnosticLog.Log("settings", "save_end", new Dictionary<string, object?>
            {
                ["durationMs"] = Environment.TickCount64 - startedAt,
                ["languageChanged"] = langChanged
            });
        }
        catch (Exception ex)
        {
            AppDiagnosticLog.LogException("settings", "save_failed", ex);
            SettingsStatusText.Text = $"Save failed: {ex.GetType().Name}: {ex.Message}";
        }
    }

    private static void SaveStep(string name, Action action)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            AppDiagnosticLog.LogException("settings", "step_failed", ex, new Dictionary<string, object?>
            {
                ["step"] = name
            });
            throw;
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private void OnCopyEndpointClick(object sender, RoutedEventArgs e) =>
        ClipboardHelper.SafeCopy(McpEndpointBox.Text);

    private void OnCopyTokenClick(object sender, RoutedEventArgs e) =>
        ClipboardHelper.SafeCopy(McpTokenBox.Text);

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
        if (enabled) _autostart.Enable(AutostartManager.GetExecutablePath());
        else _autostart.Disable();
    }

    private void LoadTransmissionSettings()
    {
        var settings = _settingsStore.LoadAmbientTransmissionSettings();
        foreach (var option in _transmissionOptions)
        {
            option.IsAllowed = TransmissionUiSettingsMerge.IsOptionEnabled(
                option.PrimaryPath, settings.PathTransmitOverrides);
        }
    }

    private void SaveTransmissionSettings()
    {
        var settings = _settingsStore.LoadAmbientTransmissionSettings();
        var enabledIds = _transmissionOptions
            .Where(o => o.IsAllowed)
            .Select(o => o.Id)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var catalogOptions = AmbientContextCatalog.GetTransmissionUiGroups()
            .SelectMany(g => g.Options).ToList();
        var overrides = TransmissionUiSettingsMerge.MergeOverrides(
            settings.PathTransmitOverrides, catalogOptions, enabledIds);

        AmbientTransmissionPolicy.Save(
            _settingsStore,
            new AmbientTransmissionSettings { SchemaVersion = 1, PathTransmitOverrides = overrides },
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
        var lang = GetSelectedLanguage();
        _settingsStore.SaveUiSettings(new UiSettings
        {
            SchemaVersion = 1,
            Language = lang
        });
        // Unpackaged WinUI 3 では Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride
        // が InvalidOperationException を投げる。settings.json 経由で次回起動時に
        // App.ApplyUiCulture が CultureInfo.CurrentUICulture を切り替えるので
        // ここでは何もしない (要再起動仕様)。
    }

    private string GetSelectedLanguage() =>
        UiLanguageBox.SelectedValue?.ToString() ?? "";

    private static int ParsePort(string text, int fallback)
    {
        return int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var port) && port is > 0 and < 65536
            ? port : fallback;
    }

    private static void SelectComboBoxValue(ComboBox comboBox, int value)
    {
        foreach (var item in comboBox.Items.OfType<ComboBoxItem>())
        {
            if (int.TryParse(item.Tag?.ToString(), out var tag) && tag == value)
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
            int.TryParse(comboBox.SelectedValue.ToString(), out var v)) return v;
        return fallback;
    }
}
