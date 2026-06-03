using AmbientContextMcp.Core.Hub;
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
/// 内部の WebApplication は独自 DI を持つため、ContextTools が要求する全依存
/// (McpServerHost, ISettingsStore, LocalContextHub) を ctor で外側 DI から受け取り
/// Kestrel 側 DI にもシングルトン登録する (DI ブリッジ)。LocalContextHub の登録が
/// 抜けると MCP SDK が tool 引数を client argument として schema に漏らし、
/// 全 4 ツールで required:["hub"] になって起動時例外になる。
/// </summary>
public sealed class McpKestrelHostedService : IHostedService
{
    private readonly McpServerHost _mcpHost;
    private readonly ISettingsStore _settingsStore;
    private readonly LocalContextHub _hub;
    private WebApplication? _app;

    public McpKestrelHostedService(McpServerHost mcpHost, ISettingsStore settingsStore, LocalContextHub hub)
    {
        _mcpHost = mcpHost;
        _settingsStore = settingsStore;
        _hub = hub;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseUrls(_mcpHost.BaseUrl);

        builder.Services.AddSingleton(_mcpHost);
        builder.Services.AddSingleton(_settingsStore);
        builder.Services.AddSingleton(_hub);

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
