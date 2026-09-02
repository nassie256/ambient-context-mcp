import Foundation
import MCP

/// `tools/list` に出す 4 ツールの定義。
///
/// name / title / description / inputSchema / annotations は C# 版 (MCP C# SDK の属性リフレクション
/// 出力) をそのまま固定したもので、`src/macos/Fixtures/contract/tools-list.json` と一致していなければ
/// ならない (`ToolsListFixtureTests` が検証する)。クライアントが引数名 `clientId` / `cursor` /
/// `scopes` 等に依存するため、勝手に整形し直さないこと。
public enum AmbientContextTools {

    public static let describeEvents = Tool(
        name: "ambient_context_describe_events",
        title: "Describe Ambient Context Event Schemas",
        description: "Returns the static event schema catalog: every event name the server can emit, its event-level sensitivity, a human description, and the list of payload keys with their per-key sensitivity and example values. Use this once to learn what to expect from ambient_context_poll_events instead of sniffing live samples. The catalog only changes between releases; cache the result.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]),
        annotations: Tool.Annotations(
            title: "Describe Ambient Context Event Schemas",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false))

    public static let getPolicy = Tool(
        name: "ambient_context_get_policy",
        title: "Get Ambient Context Transmission Policy",
        description: "Returns diagnostic metadata about Ambient Context MCP privacy classifications and effective transmission policy. This does not return sensitive context values; it explains which paths are allowed outbound by default or by user override.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]),
        annotations: Tool.Annotations(
            title: "Get Ambient Context Transmission Policy",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false))

    public static let getStates = Tool(
        name: "ambient_context_get_states",
        title: "Get Ambient Context States",
        description: "Returns the latest ambient context states. The response only includes items that satisfy BOTH (a) the user's transmission policy and (b) the client-supplied scope filter. The scope is the maximum sensitivity the client declares it can handle; raising it never bypasses the user's opt-in policy. The response includes a 'policyVersion' hash — clients can skip calling ambient_context_get_policy until that value changes. Use 'context.all:read' as a shorthand for 'I can handle anything the user permits'.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "names": .object([
                    "description": .string("Optional list of state names to return. Omit or pass an empty list to return all allowed states."),
                    "type": .array([
                        .string("array"),
                        .string("null"),
                    ]),
                    "items": .object([
                        "type": .array([
                            .string("string"),
                            .string("null"),
                        ]),
                    ]),
                    "default": .null,
                ]),
                "scopes": .object([
                    "description": .string("Optional MCP context scopes declaring the maximum sensitivity this client handles: context.low:read, context.medium:read, context.high:read, or context.all:read (alias for high). Default is context.low:read. Raising the scope only widens the response within what the user has already opted in to; it cannot bypass the user's transmission policy."),
                    "type": .array([
                        .string("array"),
                        .string("null"),
                    ]),
                    "items": .object([
                        "type": .array([
                            .string("string"),
                            .string("null"),
                        ]),
                    ]),
                    "default": .null,
                ]),
                "includeMetadata": .object([
                    "description": .string("Whether to include state metadata such as sensitivity and observed_at."),
                    "type": .string("boolean"),
                    "default": .bool(true),
                ]),
            ]),
        ]),
        annotations: Tool.Annotations(
            title: "Get Ambient Context States",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false))

    public static let pollEvents = Tool(
        name: "ambient_context_poll_events",
        title: "Poll Ambient Context Events",
        description: "Returns ambient context transition events such as idle/return, AC connect/disconnect, foreground app changes. By default this is a subscription-style call that returns events newer than the client's stored cursor and advances the cursor. When 'since' or 'until' is provided it becomes a stateless history query within that time range and the client cursor is NOT advanced, so the same range can be re-fetched. Each event also reports per-payload-key sensitivity ('payloadSensitivity') and the worst-case 'maxFieldSensitivity', so a client can tell at a glance whether raising its scope would reveal more fields. The response includes a 'policyVersion' hash — clients can skip calling ambient_context_get_policy until that value changes.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "clientId": .object([
                    "description": .string("Stable client identifier for cursor tracking. If omitted, a default MCP client id is used."),
                    "type": .string("string"),
                    "default": .string("ambient-context-mcp"),
                ]),
                "cursor": .object([
                    "description": .string("Opaque cursor returned by the previous call. Omit to start at this client's current position without replaying earlier retained events. When used with since/until it acts as a pagination offset within the time range."),
                    "type": .string("string"),
                    "default": .string(""),
                ]),
                "names": .object([
                    "description": .string("Optional list of event names to return. Omit or pass an empty list to return all allowed events."),
                    "type": .array([
                        .string("array"),
                        .string("null"),
                    ]),
                    "items": .object([
                        "type": .array([
                            .string("string"),
                            .string("null"),
                        ]),
                    ]),
                    "default": .null,
                ]),
                "scopes": .object([
                    "description": .string("Optional MCP context scopes: context.low:read, context.medium:read, context.high:read, or context.all:read (alias for high). Higher scopes reveal only medium/high data that the user's transmission policy already permits. Payload keys above the requested scope are dropped individually while the event itself can still be delivered if its event-level sensitivity is within scope."),
                    "type": .array([
                        .string("array"),
                        .string("null"),
                    ]),
                    "items": .object([
                        "type": .array([
                            .string("string"),
                            .string("null"),
                        ]),
                    ]),
                    "default": .null,
                ]),
                "limit": .object([
                    "description": .string("Maximum number of events to return. Default is 50; server caps at 1000."),
                    "type": .string("integer"),
                    "default": .int(50),
                ]),
                "since": .object([
                    "description": .string("Optional ISO 8601 timestamp (e.g. 2026-05-10T00:00:00+09:00). When provided, only events with observedAt >= since are returned, the call becomes a stateless history query (the client cursor is NOT advanced), and an absent client cursor starts at the oldest retained event instead of the latest."),
                    "type": .string("string"),
                    "default": .string(""),
                ]),
                "until": .object([
                    "description": .string("Optional ISO 8601 timestamp (e.g. 2026-05-10T23:59:59+09:00). When provided, only events with observedAt <= until are returned; same stateless semantics as 'since'."),
                    "type": .string("string"),
                    "default": .string(""),
                ]),
                "includePayload": .object([
                    "description": .string("If false, omit 'payload' and 'payloadSensitivity' from each event to reduce response size when scanning large ranges. The event's id, sequence, observedAt, name, value, sensitivity, and maxFieldSensitivity are preserved. Default true."),
                    "type": .string("boolean"),
                    "default": .bool(true),
                ]),
            ]),
        ]),
        annotations: Tool.Annotations(
            title: "Poll Ambient Context Events",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: false))

    /// `tools/list` の並び (C# SDK の登録順 = 名前の昇順)。
    public static let all: [Tool] = [describeEvents, getPolicy, getStates, pollEvents]

    /// discovery ファイル (`mcp-api.json`) の `tools` 配列。C# 版の手書き配列と同じ順序。
    public static let discoveryToolNames = [
        "ambient_context_get_policy",
        "ambient_context_describe_events",
        "ambient_context_get_states",
        "ambient_context_poll_events"
    ]
}
