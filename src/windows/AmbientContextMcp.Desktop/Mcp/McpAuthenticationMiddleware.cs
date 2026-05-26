using Microsoft.AspNetCore.Http;

namespace AmbientContextMcp.Mcp;

/// <summary>
/// Enforces local-only Origin (defense against DNS rebinding) and Bearer
/// token authentication on the /mcp endpoint.
/// </summary>
public sealed class McpAuthenticationMiddleware
{
    private const string TokenHeader = "X-AmbientContextMcp-Token";

    private readonly RequestDelegate _next;
    private readonly McpServerHost _host;

    public McpAuthenticationMiddleware(RequestDelegate next, McpServerHost host)
    {
        _next = next;
        _host = host;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        if (context.Request.Path.StartsWithSegments("/mcp"))
        {
            if (!IsAllowedOrigin(context.Request))
            {
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                await context.Response.WriteAsJsonAsync(new { error = "forbidden_origin" }).ConfigureAwait(false);
                return;
            }

            if (!IsAuthorized(context.Request, _host.Token))
            {
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                context.Response.Headers.WWWAuthenticate = "Bearer";
                await context.Response.WriteAsJsonAsync(new { error = "unauthorized" }).ConfigureAwait(false);
                return;
            }
        }

        await _next(context).ConfigureAwait(false);
    }

    private static bool IsAllowedOrigin(HttpRequest request)
    {
        if (!request.Headers.TryGetValue("Origin", out var originValues))
        {
            return true;
        }

        foreach (var origin in originValues)
        {
            if (!Uri.TryCreate(origin, UriKind.Absolute, out var uri))
            {
                return false;
            }

            if (uri.Scheme is not ("http" or "https"))
            {
                return false;
            }

            if (!IsLocalhost(uri.Host))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsAuthorized(HttpRequest request, string token)
    {
        if (string.IsNullOrWhiteSpace(token))
        {
            return false;
        }

        if (request.Headers.TryGetValue(TokenHeader, out var headerToken) &&
            string.Equals(headerToken.ToString(), token, StringComparison.Ordinal))
        {
            return true;
        }

        if (!request.Headers.TryGetValue("Authorization", out var authorization))
        {
            return false;
        }

        var value = authorization.ToString();
        return value.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) &&
               string.Equals(value["Bearer ".Length..].Trim(), token, StringComparison.Ordinal);
    }

    private static bool IsLocalhost(string host)
    {
        return host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
               host.Equals("127.0.0.1", StringComparison.OrdinalIgnoreCase) ||
               host.Equals("[::1]", StringComparison.OrdinalIgnoreCase) ||
               host.Equals("::1", StringComparison.OrdinalIgnoreCase);
    }
}
