using System.Globalization;
using AmbientContextMcp.AmbientContext;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Hosting;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Settings;
using AmbientContextMcp.Tray;
using AmbientContextMcp.Win32;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.UI.Xaml;

namespace AmbientContextMcp;

public partial class App : Application
{
    private IHost? _host;
    private SettingsWindow? _settingsWindow;

    public App()
    {
        InitializeComponent();
    }

    public IServiceProvider Services => _host?.Services
        ?? throw new InvalidOperationException("Host not started.");

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var settingsStore = new JsonFileSettingsStore();
        AppDiagnosticLog.Configure(settingsStore.SettingsPath);
        AppDiagnosticLog.Log("app", "startup", new Dictionary<string, object?>
        {
            ["settingsPath"] = settingsStore.SettingsPath
        });

        ApplyUiCulture(settingsStore.LoadUiSettings());

        var mcpHost = new McpServerHost(settingsStore);

        var builder = Microsoft.Extensions.Hosting.Host.CreateApplicationBuilder();
        builder.Services.AddSingleton<ISettingsStore>(settingsStore);
        builder.Services.AddSingleton(mcpHost);
        builder.Services.AddSingleton<MessageOnlyWindow>();
        builder.Services.AddSingleton<LocalContextHub>();
        builder.Services.AddSingleton<WindowsAmbientContextService>();
        builder.Services.AddSingleton<AutostartManager>();
        builder.Services.AddSingleton<TrayService>();
        builder.Services.AddHostedService<AmbientContextHostedService>();
        builder.Services.AddHostedService<McpKestrelHostedService>();

        _host = builder.Build();
        WireSnapshotForwarding(_host.Services);
        await _host.StartAsync();

        var tray = _host.Services.GetRequiredService<TrayService>();
        tray.Show(OpenSettings);
    }

    private void OpenSettings()
    {
        AppDiagnosticLog.Log("tray", "open_settings_requested");
        if (_settingsWindow is not null)
        {
            SettingsWindowPlacement.EnsureVisible(_settingsWindow);
            return;
        }
        try
        {
            _settingsWindow = ActivatorUtilities.CreateInstance<SettingsWindow>(Services);
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
            _settingsWindow.Activate();
        }
        catch (Exception ex)
        {
            AppDiagnosticLog.LogException("tray", "open_settings_failed", ex);
        }
    }

    private static void ApplyUiCulture(UiSettings ui)
    {
        if (string.IsNullOrWhiteSpace(ui.Language)) return;
        try
        {
            var culture = CultureInfo.GetCultureInfo(ui.Language);
            CultureInfo.DefaultThreadCurrentUICulture = culture;
            Thread.CurrentThread.CurrentUICulture = culture;
        }
        catch (CultureNotFoundException)
        {
            // 無効な culture は無視して OS 既定にフォールバック。
        }
    }

    private static void WireSnapshotForwarding(IServiceProvider services)
    {
        var collector = services.GetRequiredService<WindowsAmbientContextService>();
        var hub = services.GetRequiredService<LocalContextHub>();
        var tray = services.GetRequiredService<TrayService>();
        collector.SnapshotUpdated += (_, snapshot) =>
        {
            if (!tray.IsPaused) hub.Ingest(snapshot);
        };
    }
}
