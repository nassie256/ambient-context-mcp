using AmbientContextMcp.Core.Mcp;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace AmbientContextMcp.Hosting;

/// <summary>
/// Kestrel + ASP.NET Core MCP サーバを外側 Generic Host から起動する IHostedService。
/// 内部の WebApplication は独自 DI を持つため、共有依存 (McpServerHost, ISettingsStore) は
/// constructor で外側 DI から受け取って Kestrel 側 DI にもシングルトン登録する (DI ブリッジ)。
/// </summary>
public sealed class McpKestrelHostedService : IHostedService
{
    private readonly McpServerHost _mcpHost;
    private readonly ISettingsStore _settingsStore;
    private WebApplication? _app;

    public McpKestrelHostedService(McpServerHost mcpHost, ISettingsStore settingsStore)
    {
        _mcpHost = mcpHost;
        _settingsStore = settingsStore;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseUrls(_mcpHost.BaseUrl);

        builder.Services.AddSingleton(_mcpHost);
        builder.Services.AddSingleton(_settingsStore);

        builder.Services.AddMcpServer()
            .WithHttpTransport(options => options.Stateless = true)
            .WithTools<ContextTools>();

        _app = builder.Build();
        _app.UseMiddleware<McpAuthenticationMiddleware>();
        _app.MapMcp("/mcp");

        _app.Lifetime.ApplicationStarted.Register(() => _mcpHost.WriteDiscoveryFile());
        _app.Lifetime.ApplicationStopping.Register(McpServerHost.TryDeleteDiscoveryFile);

        await _app.StartAsync(cancellationToken);
    }

    public Task StopAsync(CancellationToken cancellationToken) =>
        _app?.StopAsync(cancellationToken) ?? Task.CompletedTask;
}
