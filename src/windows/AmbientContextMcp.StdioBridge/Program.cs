using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace AmbientContextMcp.StdioBridge;

/// <summary>
/// Thin stdio MCP shim that forwards JSON-RPC messages to the locally-running
/// AmbientContextMcp tray (Streamable HTTP at 127.0.0.1:&lt;port&gt;/mcp).
///
/// The tray owns the single LocalContextHub instance. This process must not
/// duplicate Hub state; it only relays bytes between stdio and HTTP.
/// </summary>
internal static class Program
{
    private const int StartupWaitMs = 20_000;
    private const int StartupPollIntervalMs = 250;
    private const int HealthCheckTimeoutMs = 1_500;
    private const string DotNetDownloadUrl = "https://dotnet.microsoft.com/download/dotnet/8.0";

    private static readonly HttpClient HttpClient = new()
    {
        Timeout = TimeSpan.FromMinutes(2),
    };

    public static async Task<int> Main()
    {
        // stdout is reserved for JSON-RPC. Diagnostics go to stderr.
        Console.InputEncoding = Encoding.UTF8;
        Console.OutputEncoding = Encoding.UTF8;

        try
        {
            var discovery = await EnsureUpstreamReadyAsync();
            await ProxyLoopAsync(discovery);
            return 0;
        }
        catch (BridgeStartupException ex)
        {
            await Console.Error.WriteLineAsync("ambient-mcp-stdio: " + ex.Message);
            return 1;
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync(
                $"ambient-mcp-stdio: unexpected error: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    private static async Task<Discovery> EnsureUpstreamReadyAsync()
    {
        var discoveryPath = GetDiscoveryPath();

        if (TryReadDiscovery(discoveryPath, out var existing) && await IsHealthyAsync(existing))
        {
            return existing;
        }

        var trayPath = ResolveBundledTrayPath();
        if (trayPath is null)
        {
            throw new BridgeStartupException(
                "Cannot locate ambient-mcp.exe next to this binary. The bundle appears to be incomplete.");
        }

        Process trayProcess;
        try
        {
            trayProcess = Process.Start(new ProcessStartInfo
            {
                FileName = trayPath,
                UseShellExecute = false,
                CreateNoWindow = true,
            }) ?? throw new BridgeStartupException("Failed to start ambient-mcp.exe (Process.Start returned null).");
        }
        catch (Win32Exception ex)
        {
            throw new BridgeStartupException(
                "Failed to launch ambient-mcp.exe. .NET 8 Desktop Runtime is most likely missing. " +
                "Install it from " + DotNetDownloadUrl,
                ex);
        }

        // Dispose of the Process handle when this method exits; the spawned tray itself keeps running.
        using var trayHandle = trayProcess;

        var deadline = DateTime.UtcNow.AddMilliseconds(StartupWaitMs);
        while (DateTime.UtcNow < deadline)
        {
            if (trayHandle.HasExited)
            {
                throw new BridgeStartupException(
                    $"ambient-mcp.exe exited with code {trayHandle.ExitCode} before becoming responsive. " +
                    "If the exit code indicates a missing framework, install .NET 8 Desktop Runtime: " +
                    DotNetDownloadUrl);
            }

            await Task.Delay(StartupPollIntervalMs);

            if (TryReadDiscovery(discoveryPath, out var d) && await IsHealthyAsync(d))
            {
                return d;
            }
        }

        throw new BridgeStartupException(
            $"ambient-mcp.exe did not publish a usable discovery file within {StartupWaitMs / 1000} seconds.");
    }

    private static async Task ProxyLoopAsync(Discovery discovery)
    {
        var stdin = Console.In;
        var stdout = Console.OpenStandardOutput();
        var newline = "\n"u8.ToArray();

        string? line;
        while ((line = await stdin.ReadLineAsync()) is not null)
        {
            if (line.Length == 0)
            {
                continue;
            }

            byte[]? responseBytes;
            try
            {
                responseBytes = await ForwardAsync(discovery, line);
            }
            catch (Exception ex)
            {
                responseBytes = BuildLocalErrorResponse(line, ex);
            }

            if (responseBytes is { Length: > 0 })
            {
                await stdout.WriteAsync(responseBytes);
                await stdout.WriteAsync(newline);
                await stdout.FlushAsync();
            }
        }
    }

    private static async Task<byte[]?> ForwardAsync(Discovery discovery, string jsonRpcLine)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, discovery.McpUrl)
        {
            Content = new StringContent(jsonRpcLine, Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", discovery.Token);
        request.Headers.Accept.Clear();
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

        using var response = await HttpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);

        if (response.StatusCode is HttpStatusCode.Accepted or HttpStatusCode.NoContent)
        {
            return null;
        }

        var mediaType = response.Content.Headers.ContentType?.MediaType;
        if (string.Equals(mediaType, "text/event-stream", StringComparison.OrdinalIgnoreCase))
        {
            return await ReadFirstSseDataAsync(response);
        }

        var bytes = await response.Content.ReadAsByteArrayAsync();
        return bytes.Length == 0 ? null : bytes;
    }

    private static async Task<byte[]?> ReadFirstSseDataAsync(HttpResponseMessage response)
    {
        await using var stream = await response.Content.ReadAsStreamAsync();
        using var reader = new StreamReader(stream, Encoding.UTF8);

        var dataBuffer = new StringBuilder();
        string? line;
        while ((line = await reader.ReadLineAsync()) is not null)
        {
            if (line.Length == 0)
            {
                if (dataBuffer.Length > 0)
                {
                    return Encoding.UTF8.GetBytes(dataBuffer.ToString());
                }
                continue;
            }

            if (line.StartsWith("data:", StringComparison.Ordinal))
            {
                var payload = line.Length > 5 && line[5] == ' '
                    ? line.AsSpan(6)
                    : line.AsSpan(5);
                dataBuffer.Append(payload);
            }
        }

        return dataBuffer.Length == 0 ? null : Encoding.UTF8.GetBytes(dataBuffer.ToString());
    }

    private static async Task<bool> IsHealthyAsync(Discovery discovery)
    {
        try
        {
            using var cts = new CancellationTokenSource(HealthCheckTimeoutMs);
            using var request = new HttpRequestMessage(HttpMethod.Get, discovery.BaseUrl);
            using var response = await HttpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cts.Token);
            // Any HTTP response (even 401/404) proves the tray's listener is up.
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static bool TryReadDiscovery(string path, out Discovery discovery)
    {
        discovery = default!;
        if (!File.Exists(path))
        {
            return false;
        }

        string json;
        try
        {
            json = File.ReadAllText(path);
        }
        catch
        {
            return false;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var baseUrl = root.TryGetProperty("baseUrl", out var b) ? b.GetString() : null;
            var mcpUrl = root.TryGetProperty("mcpUrl", out var m) ? m.GetString() : null;
            var token = root.TryGetProperty("token", out var t) ? t.GetString() : null;

            if (string.IsNullOrEmpty(baseUrl) || string.IsNullOrEmpty(mcpUrl) || string.IsNullOrEmpty(token))
            {
                return false;
            }

            if (root.TryGetProperty("pid", out var pidElement) &&
                pidElement.ValueKind == JsonValueKind.Number &&
                pidElement.TryGetInt32(out var pid) &&
                pid > 0 &&
                !IsProcessAlive(pid))
            {
                return false;
            }

            discovery = new Discovery(baseUrl, mcpUrl, token);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool IsProcessAlive(int pid)
    {
        try
        {
            using var _ = Process.GetProcessById(pid);
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    private static string? ResolveBundledTrayPath()
    {
        var candidate = Path.Combine(AppContext.BaseDirectory, "ambient-mcp.exe");
        return File.Exists(candidate) ? candidate : null;
    }

    private static string GetDiscoveryPath()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AmbientContextMcp",
            "mcp-api.json");
    }

    private static byte[]? BuildLocalErrorResponse(string requestLine, Exception ex)
    {
        // If the inbound message had no id (notification), JSON-RPC spec says we must not respond.
        long? id = null;
        try
        {
            using var doc = JsonDocument.Parse(requestLine);
            if (doc.RootElement.TryGetProperty("id", out var idEl))
            {
                id = idEl.ValueKind switch
                {
                    JsonValueKind.Number when idEl.TryGetInt64(out var n) => n,
                    JsonValueKind.String when long.TryParse(idEl.GetString(), out var s) => s,
                    _ => null,
                };
            }
        }
        catch (JsonException)
        {
            return null;
        }

        if (id is null)
        {
            return null;
        }

        var error = JsonSerializer.Serialize(new
        {
            jsonrpc = "2.0",
            id,
            error = new
            {
                code = -32000,
                message = $"ambient-mcp-stdio upstream error: {ex.Message}",
            },
        });
        return Encoding.UTF8.GetBytes(error);
    }

    private sealed record Discovery(string BaseUrl, string McpUrl, string Token);

    private sealed class BridgeStartupException : Exception
    {
        public BridgeStartupException(string message, Exception? inner = null)
            : base(message, inner)
        {
        }
    }
}
