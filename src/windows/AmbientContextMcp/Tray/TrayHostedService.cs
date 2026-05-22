using System.Windows.Forms;
using AmbientContextMcp.AmbientContext;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Settings;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using WpfApp = System.Windows.Application;

namespace AmbientContextMcp.Tray;

/// <summary>
/// Owns the tray STA thread that hosts <see cref="TrayHost"/> and the
/// on-demand WPF <see cref="SettingsWindow"/>. The thread pumps Win32
/// messages so NotifyIcon callbacks fire and WPF dialogs work correctly.
/// </summary>
public sealed class TrayHostedService : IHostedService
{
    private readonly ISettingsStore _settingsStore;
    private readonly McpServerHost _mcpHost;
    private readonly LocalContextHub _hub;
    private readonly WindowsAmbientContextService _collector;
    private readonly AutostartManager _autostart;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly ILogger<TrayHostedService> _logger;
    private readonly ManualResetEventSlim _ready = new(initialState: false);
    private Thread? _thread;
    private TrayHost? _tray;
    private SettingsWindow? _settingsWindow;
    private WpfApp? _wpfApp;

    public TrayHostedService(
        ISettingsStore settingsStore,
        McpServerHost mcpHost,
        LocalContextHub hub,
        WindowsAmbientContextService collector,
        AutostartManager autostart,
        IHostApplicationLifetime lifetime,
        ILogger<TrayHostedService> logger)
    {
        _settingsStore = settingsStore;
        _mcpHost = mcpHost;
        _hub = hub;
        _collector = collector;
        _autostart = autostart;
        _lifetime = lifetime;
        _logger = logger;
    }

    /// <summary>
    /// True when the user toggled "一時停止" in the tray menu. Read by the
    /// snapshot forwarder in Program.cs to suppress LocalContextHub ingestion.
    /// </summary>
    public bool IsPaused => _tray?.IsPaused ?? false;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _thread = new Thread(TrayThreadMain)
        {
            Name = "AmbientContextMcp.Tray",
            IsBackground = true
        };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        _ready.Wait(cancellationToken);
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        if (_tray is null || _thread is null)
        {
            return Task.CompletedTask;
        }

        _wpfApp?.Dispatcher.BeginInvoke(() =>
        {
            _settingsWindow?.Close();
            _wpfApp.Shutdown();
        });
        _tray.RequestExit();
        _thread.Join(TimeSpan.FromSeconds(5));
        return Task.CompletedTask;
    }

    private void TrayThreadMain()
    {
        try
        {
            ApplicationConfiguration.Initialize();

            _wpfApp = new WpfApp
            {
                ShutdownMode = System.Windows.ShutdownMode.OnExplicitShutdown
            };

            AppDiagnosticLog.Log("tray", "thread_started");

            _tray = new TrayHost(_mcpHost, _lifetime, OpenSettings);
            _ready.Set();
            Application.Run();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Tray thread crashed.");
            AppDiagnosticLog.LogException("tray", "thread_crashed", ex);
            _ready.Set();
            _lifetime.StopApplication();
        }
        finally
        {
            AppDiagnosticLog.Log("tray", "thread_exiting");
            _tray?.Dispose();
        }
    }

    private void OpenSettings()
    {
        AppDiagnosticLog.Log("tray", "open_settings_requested", new Dictionary<string, object?>
        {
            ["existingWindow"] = _settingsWindow is not null,
            ["existingVisible"] = _settingsWindow?.IsVisible == true
        });

        try
        {
            if (_settingsWindow is { IsVisible: true })
            {
                SettingsWindowPlacement.EnsureVisible(_settingsWindow);
                _settingsWindow.Activate();
                AppDiagnosticLog.Log("tray", "open_settings_activated_existing");
                return;
            }

            var window = new SettingsWindow(_settingsStore, _mcpHost, _hub, _collector, _autostart);
            window.Closed += (_, _) =>
            {
                if (ReferenceEquals(_settingsWindow, window))
                {
                    _settingsWindow = null;
                }

                AppDiagnosticLog.Log("tray", "settings_window_closed");
            };
            _settingsWindow = window;
            window.Show();
            AppDiagnosticLog.Log("tray", "open_settings_show_new", new Dictionary<string, object?>
            {
                ["left"] = window.Left,
                ["top"] = window.Top,
                ["width"] = window.Width,
                ["height"] = window.Height
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to open settings window.");
            AppDiagnosticLog.LogException("tray", "open_settings_failed", ex);
        }
    }
}
