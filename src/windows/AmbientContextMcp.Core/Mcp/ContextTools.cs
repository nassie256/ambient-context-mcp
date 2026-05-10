using System.ComponentModel;
using System.Globalization;
using System.Text.Json;
using AmbientContextMcp.Core.Hub;
using ModelContextProtocol.Server;

namespace AmbientContextMcp.Core.Mcp;

[McpServerToolType]
public sealed class ContextTools
{
    [McpServerTool(Name = "ambient.context.get_policy", Title = "Get Ambient Context Transmission Policy", ReadOnly = true, Destructive = false, Idempotent = true, OpenWorld = false)]
    [Description("Returns diagnostic metadata about Ambient Context MCP privacy classifications and effective transmission policy. This does not return sensitive context values; it explains which paths are allowed outbound by default or by user override.")]
    public static string GetPolicy(LocalContextHub hub)
    {
        ArgumentNullException.ThrowIfNull(hub);
        var response = hub.GetPolicy();
        return JsonSerializer.Serialize(response, AmbientContextJson.Options);
    }

    [McpServerTool(Name = "ambient.context.get_states", Title = "Get Ambient Context States", ReadOnly = true, Destructive = false, Idempotent = true, OpenWorld = false)]
    [Description("Returns the latest ambient context states. The response only includes items that satisfy BOTH (a) the user's transmission policy and (b) the client-supplied scope filter. The scope is the maximum sensitivity the client declares it can handle; raising it never bypasses the user's opt-in policy. Use ambient.context.get_policy to inspect what the user has allowed.")]
    public static string GetStates(
        LocalContextHub hub,
        [Description("Optional list of state names to return. Omit or pass an empty list to return all allowed states.")]
        string[]? names = null,
        [Description("Optional MCP context scopes declaring the maximum sensitivity this client handles: context.low:read, context.medium:read, or context.high:read. Default is context.low:read. Raising the scope only widens the response within what the user has already opted in to; it cannot bypass the user's transmission policy.")]
        string[]? scopes = null,
        [Description("Whether to include state metadata such as sensitivity and observed_at.")]
        bool includeMetadata = true)
    {
        ArgumentNullException.ThrowIfNull(hub);
        var response = hub.GetContextStates(new LocalContextStateRequest
        {
            Names = names ?? [],
            Scopes = scopes ?? [],
            IncludeMetadata = includeMetadata
        });
        return JsonSerializer.Serialize(response, AmbientContextJson.Options);
    }

    [McpServerTool(Name = "ambient.context.poll_events", Title = "Poll Ambient Context Events", ReadOnly = true, Destructive = false, Idempotent = false, OpenWorld = false)]
    [Description("Returns ambient context transition events such as idle/return, AC connect/disconnect, foreground app changes. By default this is a subscription-style call that returns events newer than the client's stored cursor and advances the cursor. When 'since' or 'until' is provided it becomes a stateless history query within that time range and the client cursor is NOT advanced, so the same range can be re-fetched. Filtering rules are the same as ambient.context.get_states: an event is returned only if it satisfies BOTH the user's transmission policy and the client-supplied scope.")]
    public static string PollEvents(
        LocalContextHub hub,
        [Description("Stable client identifier for cursor tracking. If omitted, a default MCP client id is used.")]
        string clientId = "ambient-context-mcp",
        [Description("Opaque cursor returned by the previous call. Omit to start at this client's current position without replaying earlier retained events. When used with since/until it acts as a pagination offset within the time range.")]
        string cursor = "",
        [Description("Optional list of event names to return. Omit or pass an empty list to return all allowed events.")]
        string[]? names = null,
        [Description("Optional MCP context scopes: context.low:read, context.medium:read, or context.high:read. Higher scopes reveal only medium/high events that the user's transmission policy already permits.")]
        string[]? scopes = null,
        [Description("Maximum number of events to return. Default is 50; server caps at 1000.")]
        int limit = 50,
        [Description("Optional ISO 8601 timestamp (e.g. 2026-05-10T00:00:00+09:00). When provided, only events with observedAt >= since are returned, the call becomes a stateless history query (the client cursor is NOT advanced), and an absent client cursor starts at the oldest retained event instead of the latest.")]
        string since = "",
        [Description("Optional ISO 8601 timestamp (e.g. 2026-05-10T23:59:59+09:00). When provided, only events with observedAt <= until are returned; same stateless semantics as 'since'.")]
        string until = "")
    {
        ArgumentNullException.ThrowIfNull(hub);
        var response = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = clientId,
            Cursor = cursor,
            Names = names ?? [],
            Scopes = scopes ?? [],
            Limit = limit,
            Since = ParseOptionalTimestamp(since, nameof(since)),
            Until = ParseOptionalTimestamp(until, nameof(until))
        });
        return JsonSerializer.Serialize(response, AmbientContextJson.Options);
    }

    private static DateTimeOffset? ParseOptionalTimestamp(string value, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        if (DateTimeOffset.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeLocal,
            out var parsed))
        {
            return parsed;
        }

        throw new ArgumentException(
            $"'{parameterName}' must be an ISO 8601 timestamp such as 2026-05-10T00:00:00+09:00.",
            parameterName);
    }
}
