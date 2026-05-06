using System.Globalization;
using AmbientContextMcp.AmbientContext;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Mcp;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Resources;
using AmbientContextMcp.Tray;
using AmbientContextMcp.Win32;

var settingsStore = new JsonFileSettingsStore();

// UI culture を設定ストアから先に決める。これより後に Strings の static フィールド
// (T(...) で IsEnglish を一度だけ参照) と PrivacyClassification.Reason の解決が
// 走るため、ここで culture を確定させないと言語が安定しない。
ApplyUiCulture(settingsStore.LoadUiSettings());

var mcpHost = new McpServerHost(settingsStore);

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls(mcpHost.BaseUrl);

builder.Services.AddSingleton<ISettingsStore>(settingsStore);
builder.Services.AddSingleton(mcpHost);
builder.Services.AddSingleton<MessageOnlyWindow>();
builder.Services.AddSingleton<LocalContextHub>();
builder.Services.AddSingleton<WindowsAmbientContextService>();
builder.Services.AddSingleton<AutostartManager>();
builder.Services.AddSingleton<TrayHostedService>();
builder.Services.AddHostedService<AmbientContextHostedService>();
builder.Services.AddHostedService(provider => provider.GetRequiredService<TrayHostedService>());

builder.Services.AddMcpServer()
    .WithHttpTransport(options =>
    {
        options.Stateless = true;
    })
    .WithTools<ContextTools>();

var app = builder.Build();

WireSnapshotForwarding(app.Services);

app.UseMiddleware<McpAuthenticationMiddleware>();
app.MapMcp("/mcp");

app.Lifetime.ApplicationStarted.Register(() =>
    app.Services.GetRequiredService<McpServerHost>().WriteDiscoveryFile());
app.Lifetime.ApplicationStopping.Register(McpServerHost.TryDeleteDiscoveryFile);

try
{
    app.Run();
}
catch (Exception ex)
{
    System.Windows.Forms.MessageBox.Show(
        string.Format(
            CultureInfo.InvariantCulture,
            Strings.StartupErrorFormat,
            $"{ex.GetType().Name}: {ex.Message}",
            mcpHost.Settings.Port),
        "Ambient Context MCP",
        System.Windows.Forms.MessageBoxButtons.OK,
        System.Windows.Forms.MessageBoxIcon.Error);
    Environment.ExitCode = 1;
}
return;

static void ApplyUiCulture(UiSettings ui)
{
    if (string.IsNullOrWhiteSpace(ui.Language))
    {
        return;
    }

    try
    {
        var culture = CultureInfo.GetCultureInfo(ui.Language);
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        Thread.CurrentThread.CurrentUICulture = culture;
    }
    catch (CultureNotFoundException)
    {
        // 設定ファイルに無効な culture が入っていた場合は無視して OS 既定にフォールバック。
    }
}

static void WireSnapshotForwarding(IServiceProvider services)
{
    var collector = services.GetRequiredService<WindowsAmbientContextService>();
    var hub = services.GetRequiredService<LocalContextHub>();
    var tray = services.GetRequiredService<TrayHostedService>();
    collector.SnapshotUpdated += (_, snapshot) =>
    {
        if (!tray.IsPaused)
        {
            hub.Ingest(snapshot);
        }
    };
}
