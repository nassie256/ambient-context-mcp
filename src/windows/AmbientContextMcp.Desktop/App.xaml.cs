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
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using AmbientContextMcp.Bootstrap;
using AmbientContextMcp.Resources;

namespace AmbientContextMcp;

public partial class App : Application
{
    private IHost? _host;
    private SettingsWindow? _settingsWindow;
    private Window? _shutdownAnchor;
    private bool _shuttingDown;

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

        try
        {
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
            WireGracefulShutdown(_host);

            // Anchor Window: WinUI 3 は「最後の Window が閉じると App.Exit」を発火する。
            // Settings ダイアログを閉じても常駐し続けるよう、不可視のダミーを 1 つ保持する。
            _shutdownAnchor = new Window { Title = "AmbientContextMcp.AnchorWindow" };
            _shutdownAnchor.Activate();
            _shutdownAnchor.AppWindow.Hide();

            var tray = _host.Services.GetRequiredService<TrayService>();
            tray.Show(OpenSettings);
        }
        catch (Exception ex)
        {
            // ホスト起動失敗 (ポート競合など)。async void から例外が漏れると
            // 無言クラッシュになるため、ログ + MessageBox で原因を提示して終了する。
            AppDiagnosticLog.LogException("app", "startup_failed", ex);
            RuntimeBootstrap.ShowFatalError(string.Format(
                CultureInfo.InvariantCulture,
                Strings.StartupErrorFormat,
                $"{ex.GetType().Name}: {ex.Message}",
                mcpHost.Settings.Port));
            Environment.Exit(1);
        }
    }

    // トレイの「終了」は IHostApplicationLifetime.StopApplication() を呼ぶだけなので、
    // ここで ApplicationStopping を捕まえてホストを破棄し、Application.Exit() で
    // メッセージループ (Anchor Window が生かしている) を確実に終わらせる。
    // これが無いと StopApplication してもプロセスが残り、トレイアイコンも消えない。
    private void WireGracefulShutdown(IHost host)
    {
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        var lifetime = host.Services.GetRequiredService<IHostApplicationLifetime>();
        lifetime.ApplicationStopping.Register(() => dispatcher.TryEnqueue(() => _ = ShutdownAsync()));
    }

    private async Task ShutdownAsync()
    {
        if (_shuttingDown) return;
        _shuttingDown = true;
        AppDiagnosticLog.Log("app", "shutdown_begin");
        try
        {
            if (_host is not null)
            {
                await _host.StopAsync();
                // DI singleton (TrayService 含む) が破棄され、トレイアイコンも除去される。
                // IHost は IDisposable のみ公開 (IAsyncDisposable は具象型側)。
                _host.Dispose();
            }
        }
        catch (Exception ex)
        {
            AppDiagnosticLog.LogException("app", "shutdown_failed", ex);
        }
        finally
        {
            Application.Current.Exit();
        }
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
