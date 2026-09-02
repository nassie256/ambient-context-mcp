import Foundation
import MCP

/// Stub tool surface for the PoC. Names/descriptions follow the Windows
/// `ContextTools` wording; payloads are fixed JSON so that the transport, not
/// the engine, is what is being verified.
let serverInfo = Server.Info(name: "ambient-context-mcp-poc", version: "0.0.1")
let serverCapabilities = Server.Capabilities(tools: .init(listChanged: false))

enum PocTools {
    static let getStates = Tool(
        name: "ambient_context_get_states",
        description: """
            Returns the latest ambient context states. The response only includes items that satisfy \
            BOTH (a) the user's transmission policy and (b) the client-supplied scope filter. \
            The response includes a 'policyVersion' hash — clients can skip calling \
            ambient_context_get_policy until that value changes.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "names": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Optional list of state names to return. Omit or pass an empty list to return all allowed states."
                    ),
                ]),
                "scopes": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Optional MCP context scopes declaring the maximum sensitivity this client handles: context.low:read, context.medium:read, context.high:read, or context.all:read."
                    ),
                ]),
                "includeMetadata": .object([
                    "type": .string("boolean"),
                    "default": .bool(true),
                    "description": .string(
                        "Whether to include state metadata such as sensitivity and observed_at."
                    ),
                ]),
            ]),
        ])
    )

    static let getPolicy = Tool(
        name: "ambient_context_get_policy",
        description: """
            Returns diagnostic metadata about Ambient Context MCP privacy classifications and \
            effective transmission policy. This does not return sensitive context values.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let all = [getStates, getPolicy]

    static func callGetStates(_ arguments: [String: Value]?) -> String {
        let names = arguments?["names"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let scopes = arguments?["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? ["context.low:read"]
        let includeMetadata = arguments?["includeMetadata"]?.boolValue ?? true

        let states: [[String: Any]] = [
            [
                "name": "presence",
                "value": "active",
                "sensitivity": "low",
                "observedAt": "2026-09-03T12:00:00+09:00",
            ],
            [
                "name": "foreground_app_category",
                "value": "editor",
                "sensitivity": "medium",
                "observedAt": "2026-09-03T12:00:00+09:00",
            ],
        ]

        let payload: [String: Any] = [
            "policyVersion": "poc-0000000000000000",
            "requestedScopes": scopes,
            "requestedNames": names,
            "states": includeMetadata
                ? states
                : states.map { ["name": $0["name"]!, "value": $0["value"]!] },
        ]
        return encode(payload)
    }

    static func callGetPolicy() -> String {
        encode([
            "policyVersion": "poc-0000000000000000",
            "defaultScope": "context.low:read",
            "paths": [
                ["path": "presence", "sensitivity": "low", "transmitByDefault": true],
                ["path": "foreground_app.title", "sensitivity": "high", "transmitByDefault": false],
            ],
        ])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

func makeServer() -> Server {
    Server(
        name: serverInfo.name,
        version: serverInfo.version,
        capabilities: serverCapabilities
    )
}

func registerHandlers(on server: Server) async {
    // The SDK's built-in `Initialize` handler rejects a second `initialize` with
    // "Server is already initialized". In stateless mode a single long-lived
    // `Server` sees one `initialize` per client session, so that default breaks
    // every client after the first. Override it with an idempotent handler.
    await server.withMethodHandler(Initialize.self) { params in
        let negotiated = Version.supported.contains(params.protocolVersion)
            ? params.protocolVersion : Version.latest
        return Initialize.Result(
            protocolVersion: negotiated,
            capabilities: serverCapabilities,
            serverInfo: serverInfo
        )
    }

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: PocTools.all)
    }
    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case PocTools.getStates.name:
            return .init(
                content: [.text(text: PocTools.callGetStates(params.arguments), annotations: nil, _meta: nil)], isError: false)
        case PocTools.getPolicy.name:
            return .init(content: [.text(text: PocTools.callGetPolicy(), annotations: nil, _meta: nil)], isError: false)
        default:
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
