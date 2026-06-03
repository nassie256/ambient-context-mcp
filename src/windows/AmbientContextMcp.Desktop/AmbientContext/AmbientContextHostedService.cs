using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace AmbientContextMcp.AmbientContext;

/// <summary>
/// Drives <see cref="WindowsAmbientContextService"/>: starts collection on
/// app start and triggers a periodic capture every minute. Captures are
/// posted to the message-only window thread inside the service so they
/// serialize with Win32 callbacks.
/// </summary>
public sealed class AmbientContextHostedService : BackgroundService
{
    private readonly WindowsAmbientContextService _service;
    private readonly ILogger<AmbientContextHostedService> _logger;

    public AmbientContextHostedService(
        WindowsAmbientContextService service,
        ILogger<AmbientContextHostedService> logger)
    {
        _service = service;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _service.Start();
        var interval = TimeSpan.FromSeconds(WindowsAmbientContextService.CaptureIntervalSeconds);
        using var timer = new PeriodicTimer(interval);

        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false))
            {
                _service.RequestPeriodicCapture();
            }
        }
        catch (OperationCanceledException)
        {
            // Expected on shutdown.
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Ambient context periodic capture loop exited unexpectedly.");
        }
    }
}
