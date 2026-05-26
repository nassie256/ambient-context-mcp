using System.Globalization;
using AmbientContextMcp.AmbientContext;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Hosting;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Win32;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.UI.Xaml;

namespace AmbientContextMcp;

public partial class App : Application
{
    private IHost? _host;

    public App()
    {
        InitializeComponent();
    }

    public IServiceProvider Services => _host?.Services
        ?? throw new InvalidOperationException("Host not started.");

    public IHost? Host => _host;

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
        builder.Services.AddHostedService<AmbientContextHostedService>();
        builder.Services.AddHostedService<McpKestrelHostedService>();
        // Tray / SettingsWindow は後続 Task で追加

        _host = builder.Build();
        WireSnapshotForwarding(_host.Services);
        await _host.StartAsync();
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
        // Tray 一時停止状態は Task 7 で接続 (現状は無条件 Ingest)。
        collector.SnapshotUpdated += (_, snapshot) => hub.Ingest(snapshot);
    }
}
