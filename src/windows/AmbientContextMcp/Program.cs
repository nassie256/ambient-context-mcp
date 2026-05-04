using AmbientContextMcp.AmbientContext;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Mcp;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Tray;
using AmbientContextMcp.Win32;

var settingsStore = new JsonFileSettingsStore();
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
        $"Ambient Context MCP の起動に失敗しました。\n\n" +
        $"{ex.GetType().Name}: {ex.Message}\n\n" +
        $"ポート {mcpHost.Settings.Port} が他プロセスで使用中の可能性があります。\n" +
        $"%LOCALAPPDATA%\\AmbientContextMcp\\settings.json の mcpServer.port を変更するか、" +
        $"同ファイルを削除して再起動してください。",
        "Ambient Context MCP",
        System.Windows.Forms.MessageBoxButtons.OK,
        System.Windows.Forms.MessageBoxIcon.Error);
    Environment.ExitCode = 1;
}
return;

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
