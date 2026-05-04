using System.ComponentModel;
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
    [Description("Returns unread ambient context transition events such as idle/return, AC connect/disconnect. Filtering rules are the same as ambient.context.get_states: an event is returned only if it satisfies BOTH the user's transmission policy and the client-supplied scope. Raising the scope cannot reveal events the user has not opted in to.")]
    public static string PollEvents(
        LocalContextHub hub,
        [Description("Stable client identifier for cursor tracking. If omitted, a default MCP client id is used.")]
        string clientId = "ambient-context-mcp",
        [Description("Opaque cursor returned by the previous call. Omit to start at this client's current position without replaying earlier retained events.")]
        string cursor = "",
        [Description("Optional list of event names to return. Omit or pass an empty list to return all allowed events.")]
        string[]? names = null,
        [Description("Optional MCP context scopes: context.low:read, context.medium:read, or context.high:read. Higher scopes reveal only medium/high events that the user's transmission policy already permits.")]
        string[]? scopes = null,
        [Description("Maximum number of events to return. Default is 50; server caps larger values.")]
        int limit = 50)
    {
        ArgumentNullException.ThrowIfNull(hub);
        var response = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = clientId,
            Cursor = cursor,
            Names = names ?? [],
            Scopes = scopes ?? [],
            Limit = limit
        });
        return JsonSerializer.Serialize(response, AmbientContextJson.Options);
    }
}
