import Foundation

/// C# `ContextTools` の中身 (MCP SDK 属性を除いた本体) を素の Swift 関数として公開する。
/// MCP ツールとしての登録 (名前 / description / inputSchema) は Phase 2 の
/// `AmbientContextMcpServer` 側で行う。
public enum ContextToolsCore {
    /// `ambient_context_get_policy`
    public static func getPolicy(hub: LocalContextHub) -> String {
        AmbientContextJson.string(hub.getPolicy())
    }

    /// `ambient_context_describe_events`
    public static func describeEvents(hub: LocalContextHub) -> String {
        AmbientContextJson.string(hub.getEventSchemas())
    }

    /// `ambient_context_get_states`
    public static func getStates(
        hub: LocalContextHub,
        names: [String]? = nil,
        scopes: [String]? = nil,
        includeMetadata: Bool = true
    ) -> String {
        let response = hub.getContextStates(LocalContextStateRequest(
            names: names ?? [],
            scopes: scopes ?? [],
            includeMetadata: includeMetadata))
        return AmbientContextJson.string(response)
    }

    /// `ambient_context_poll_events`
    /// `since` / `until` は ISO 8601 文字列。解析できない場合は `ContextToolsError.invalidArgument` を投げる。
    public static func pollEvents(
        hub: LocalContextHub,
        clientId: String = "ambient-context-mcp",
        cursor: String = "",
        names: [String]? = nil,
        scopes: [String]? = nil,
        limit: Int = 50,
        since: String = "",
        until: String = "",
        includePayload: Bool = true
    ) throws -> String {
        let response = hub.pollEvents(LocalContextPollRequest(
            clientId: clientId,
            cursor: cursor,
            names: names ?? [],
            scopes: scopes ?? [],
            limit: limit,
            since: try parseOptionalTimestamp(since, parameterName: "since"),
            until: try parseOptionalTimestamp(until, parameterName: "until"),
            includePayload: includePayload))
        return AmbientContextJson.string(response)
    }

    static func parseOptionalTimestamp(_ value: String, parameterName: String) throws -> Date? {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        if let parsed = AmbientDateFormat.parse(value) {
            return parsed
        }
        throw ContextToolsError.invalidArgument(
            parameterName: parameterName,
            message: "'\(parameterName)' must be an ISO 8601 timestamp such as 2026-05-10T00:00:00+09:00.")
    }
}

public enum ContextToolsError: Error, Equatable, CustomStringConvertible {
    case invalidArgument(parameterName: String, message: String)

    public var description: String {
        switch self {
        case .invalidArgument(_, let message): return message
        }
    }
}
